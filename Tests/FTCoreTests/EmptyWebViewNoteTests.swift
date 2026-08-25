// 委譲した WebView が**中身を出さないまま待ちを使い切った木**で判定したことを、
// 通った回にも残すこと。
//
// 待ちの上限(WebViewDelegatingDriver.contentWaitMs = 5000)は **Simulator の実測 2.3s** に対する
// 余裕でしかなく、hybrid は実機でも動く = 尽きること自体が想定内。尽きたときに黙って空の木を
// 返すと、**否定アサーションは必ず通る**(空の木に要素は無い)。判定は変えられない
// (「AX がまだ公開されていない」と「本当に空のページ」は木から区別できない)ので、
// **黙らないこと**が唯一の防御になる —— 緑は証拠にならないので、注記が付くことを直接見る。

import XCTest
@testable import FTCore

/// webViewPath を指定した空の木を返すドライバ
private final class EmptyWebViewDriver: AppDriver {
    private let path: String?

    init(path: String?) { self.path = path }

    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: [ElementInfo(ref: 1, type: "webView", identifier: nil,
                                                label: nil, value: nil, placeholder: nil,
                                                enabled: true,
                                                frame: FTRect(x: 0, y: 0, width: 400, height: 800),
                                                depth: 1)],
                         truncatedCount: 0, webViewPath: path)
    }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class EmptyWebViewNoteTests: XCTestCase {

    private func notExist(_ id: String) -> FlowStep {
        FlowStep(assert: "notExists", locator: FlowLocator(id: id), timeout: 0, occlusionGuard: false)
    }

    /// **通った不在**にこそ注記が要る(空の木では必ず通るため)
    func testAPassingAbsenceOnAnUnrenderedWebViewCarriesTheNote() async {
        let driver = EmptyWebViewDriver(path: WebViewPath.delegatedEmpty)
        let outcome = await StepExecutor(driver: driver).execute(notExist("submit"))
        XCTAssertTrue(outcome.notes.contains(.webViewNotRendered),
                      "空の WebView で成立した不在が黙って通った: \(outcome.notes) / \(outcome.status)")
    }

    /// 逆方向: 中身が出ている委譲画面には付けない(毎回出る注記にしない)
    func testARenderedDelegatedWebViewCarriesNoNote() async {
        let driver = EmptyWebViewDriver(path: WebViewPath.delegated)
        let outcome = await StepExecutor(driver: driver).execute(notExist("submit"))
        XCTAssertFalse(outcome.notes.contains(.webViewNotRendered), "\(outcome.notes)")
    }

    /// WebView と無関係な画面にも付けない
    func testANonWebViewScreenCarriesNoNote() async {
        let driver = EmptyWebViewDriver(path: nil)
        let outcome = await StepExecutor(driver: driver).execute(notExist("submit"))
        XCTAssertFalse(outcome.notes.contains(.webViewNotRendered), "\(outcome.notes)")
    }

    /// 肯定側(見つからない失敗)では**文言でも**理由を言う ——
    /// 「要素が無い」と「まだ描かれていない」を読み手が取り違えないため
    func testTheFailureMessageExplainsTheUnrenderedWebView() async {
        let driver = EmptyWebViewDriver(path: WebViewPath.delegatedEmpty)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "submit"),
                            timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver).execute(step)
        guard case .failed(let reason) = outcome.status else {
            return XCTFail("見つからないので失敗するはず: \(outcome.status)")
        }
        XCTAssertTrue(reason.contains("produced no content"), reason)
        XCTAssertTrue(outcome.notes.contains(.webViewNotRendered), "\(outcome.notes)")
    }

    /// 否定テキスト比較・count も同じ木で判定するので同じ注記が要る
    func testTheNoteAlsoReachesCountAndNegativeTextAsserts() async {
        let count = await StepExecutor(driver: EmptyWebViewDriver(path: WebViewPath.delegatedEmpty))
            .execute(FlowStep(assert: "count", locator: FlowLocator(type: "clickable"),
                              timeout: 0, expectedCount: 0))
        XCTAssertTrue(count.notes.contains(.webViewNotRendered), "count: \(count.notes)")

        let negative = await StepExecutor(driver: EmptyWebViewDriver(path: WebViewPath.delegatedEmpty))
            .execute(FlowStep(assert: "textNotEquals", locator: FlowLocator(id: "submit"),
                              expected: "送信", timeout: 0, occlusionGuard: false))
        XCTAssertTrue(negative.notes.contains(.webViewNotRendered), "negative text: \(negative.notes)")
    }
}
