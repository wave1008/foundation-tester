// 残ったアラートを消す口の配線をソース走査で固定する。緑の run ではアラートが残らないので、
// 「呼ばなくなった」「シナリオの区間の中で呼ぶようになった」はどのデバイス実行でも緑のまま通る

import XCTest

final class ResidualSystemAlertClearingWiringTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// 各シナリオの直前・録画の区間と進捗の開始より前に呼ぶ
    func testCalledBeforeEachScenarioAndBeforeItsRecordingInterval() throws {
        let text = try source("Sources/FTCore/RunOrchestrator.swift")
        let loop = try XCTUnwrap(text.range(of: "let item = await queue.next() {"))
        let call = try XCTUnwrap(text.range(of: "await clearResidualSystemAlert?(worker)", range: loop.upperBound..<text.endIndex))
        let recording = try XCTUnwrap(text.range(of: "await videoRecording?.scenarioStarted(", range: loop.upperBound..<text.endIndex))
        XCTAssertLessThan(call.lowerBound, recording.lowerBound)
    }

    /// init に既定値を置かない(渡し忘れをコンパイルで止める)
    func testInitParameterHasNoDefault() throws {
        let text = try source("Sources/FTCore/RunOrchestrator.swift")
        XCTAssertTrue(text.contains("clearResidualSystemAlert: (@Sendable (RunWorker) async -> String?)?,"))
        XCTAssertFalse(text.contains("clearResidualSystemAlert: (@Sendable (RunWorker) async -> String?)? = nil"))
    }

    /// 3段目は SpringBoard の起こし直し(ボタンを押さない)+ 同じデバイスのブリッジの作り直し
    func testDismissesByRestartingSpringBoardAndRebuildsTheBridge() throws {
        let text = try source("Sources/FTAndroid/ProfileWorkerFactory.swift")
        let start = try XCTUnwrap(text.range(of: "static func respringAndRebuild("))
        let body = String(text[start.lowerBound...].prefix(4000))
        XCTAssertTrue(body.contains("\"system/com.apple.SpringBoard\""))
        XCTAssertTrue(body.contains("BridgeLauncher.stopRunnersMatching(udid: udid"))
        XCTAssertTrue(body.contains(".provision("))
        // 押すのは FTCore の一覧から選んだボタンだけ(アラートの子孫・完全一致)
        let press = try XCTUnwrap(text.range(of: "static func pressResidualAlertButton("))
        let pressBody = String(text[press.lowerBound...].prefix(1500))
        XCTAssertTrue(pressBody.contains("ResidualSystemAlertClearing.buttonRef(label: button"))
        // SpringBoard の木とその ref の名前空間で押す(アプリの木にはアラートが写らない)
        XCTAssertTrue(pressBody.contains("client.systemUISnapshot()"))
        XCTAssertEqual(text.components(separatedBy: "client.systemUITap(ref:").count - 1, 1, "only one place presses a button")
        // 確認の問い合わせが取れないこと(nil)を「消えた」に倒さない
        XCTAssertTrue(body.contains("guard let after = await probeSystemAlert(client) else {"))
    }
}
