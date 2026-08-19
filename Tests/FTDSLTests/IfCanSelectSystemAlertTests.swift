import XCTest
@testable import FTDSL
import FTCore

/// `ifCanSelect` がシステム許可アラートに阻まれたときの振る舞い。
///
/// **one-shot のガードは窓が過ぎたら戻ってこない**ので、ここで閉じないとオンボーディングの
/// ガード列がアラートの上を全部素通りし、後続の exist 系で自動押下が効いた頃には手遅れになる
/// (受け手が実際に踏んだ形)。閉じたうえで**要求された要素を見直す**ところまでが契約
final class IfCanSelectSystemAlertTests: XCTestCase {

    private static func element(_ type: String, id: String? = nil, label: String?,
                                depth: Int, ref: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: depth)
    }

    /// アラートが閉じるまで対象を出さないアプリ側
    private final class AppDriverStub: AppDriver, @unchecked Sendable {
        var showsTarget = false
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(
                sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: showsTarget
                    ? [element("button", id: "btnStart", label: "はじめる", depth: 0, ref: 9)] : [],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    /// SpringBoard 参照セッション。押されたらアプリ側の画面を進める
    private final class AlertDriverStub: AppDriver, @unchecked Sendable {
        let app: AppDriverStub
        private(set) var tappedRefs: [Int] = []
        var dismissed = false
        init(app: AppDriverStub) { self.app = app }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(
                sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: dismissed ? [] : [
                    element("alert", label: "位置情報の使用を許可しますか?", depth: 1, ref: 1),
                    element("button", label: "許可しない", depth: 2, ref: 2),
                    element("button", label: "アプリの使用中は許可", depth: 2, ref: 3),
                ],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws {
            tappedRefs.append(ref)
            dismissed = true
            app.showsTarget = true
        }
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func makeCore(app: AppDriver, alert: AppDriver,
                          buttons: [String]) -> FTDriveCore {
        FTDriveCore(driver: app, platform: "ios", app: "com.example.app",
                    systemAlertButtons: buttons,
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, dryRun: false,
                    healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-ifcanselect-alert-test.json"),
                    fallbackDriver: alert,
                    emit: { _ in })
    }

    /// 本命: アラートに阻まれたガードが、閉じたうえで**成立する**こと
    func testガードがアラートを閉じて見直す() {
        let app = AppDriverStub()
        let alert = AlertDriverStub(app: app)
        FTRuntime.bootstrap(core: makeCore(app: app, alert: alert,
                                           buttons: ["アプリの使用中は許可", "許可"]),
                            dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var ran = false
        scenario { scene(1, "s") { action { ifCanSelect("#btnStart") { ran = true } } } }

        XCTAssertEqual(alert.tappedRefs, [3], "一覧の先頭に一致するボタンを押すこと")
        XCTAssertTrue(ran, "閉じた後に見直して成立させること(閉じただけで not met は無意味)")
    }

    /// 陰性対照: ラベル未設定なら閉じない(= 従来どおり not met)
    func testラベル未設定なら閉じない() {
        let app = AppDriverStub()
        let alert = AlertDriverStub(app: app)
        FTRuntime.bootstrap(core: makeCore(app: app, alert: alert, buttons: []),
                            dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var ran = false
        scenario { scene(1, "s") { action { ifCanSelect("#btnStart") { ran = true } } } }

        XCTAssertTrue(alert.tappedRefs.isEmpty, "設定していないのに押してはいけない")
        XCTAssertFalse(ran)
    }

    /// **シナリオ自身のアラート操作は奪わない**: 要求された要素が SpringBoard 側で解決できたら、
    /// 自動押下は走らずに成立だけする(body の中で利用者が押す)
    func testアラートのボタン自体を要求したら自動では押さない() {
        let app = AppDriverStub()
        let alert = AlertDriverStub(app: app)
        FTRuntime.bootstrap(core: makeCore(app: app, alert: alert,
                                           buttons: ["アプリの使用中は許可"]),
                            dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var ran = false
        scenario { scene(1, "s") { action { ifCanSelect("アプリの使用中は許可") { ran = true } } } }

        XCTAssertTrue(ran, "SpringBoard 側で解決できるので成立すること")
        XCTAssertTrue(alert.tappedRefs.isEmpty,
                      "解決できたなら自動押下は走らせない(シナリオの操作を奪わない)")
    }
}
