import XCTest

@testable import FTDSL
import FTCore

/// 自己修復(指紋照合)で**通った**とき、その提案が run 記録まで残ること。
/// ここが切れると「緑だがセレクタは壊れている」を後から数えられない
/// (RunResultsQuery の healReliance / RunRecord.build の doc 参照)。
/// デバイスを使わずに、DSL → ScenarioEvent → ScenarioRecordBuilder の全段を通す。
final class HealSuggestionRecordingTests: XCTestCase {

    /// 指定した id の `OK` ボタンだけが在る画面
    private final class ScreenDriver: AppDriver {
        let id: String
        init(id: String) { self.id = id }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(
                sessionBundleID: nil,
                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [ElementInfo(ref: 1, type: "button", identifier: id, label: "OK",
                                       value: nil, placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 0)],
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

    /// 両 run が同じソース行から呼ぶ(指紋の鍵に file:line が入るため)
    private func runTapOnOldID() {
        scenario { scene(1, "s") { action { tap("#old_id") } } }
    }

    private func makeCore(id: String, fingerprints: URL, emit: @escaping (ScenarioEvent) -> Void) -> FTDriveCore {
        FTDriveCore(
            driver: ScreenDriver(id: id), platform: "ios", app: "com.example.app",
            scenarioID: "Heal.S0010", scenarioTitle: "t",
            delegate: nil, healingEnabled: true,
            falsePositiveCheckEnabled: false, dryRun: false,
            fingerprintCacheURL: fingerprints,
            emit: emit)
    }

    func testHealSuggestionSurvivesIntoThePassingRunRecord() throws {
        let fingerprints = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-heal-record-test-\(UUID().uuidString).json")

        // run1: `#old_id` がプライマリで解決 → 指紋(button + "OK")を録る
        do {
            let core = makeCore(id: "old_id", fingerprints: fingerprints, emit: { _ in })
            FTRuntime.bootstrap(core: core, dslThread: Thread.current)
            defer { FTRuntime.tearDown() }
            runTapOnOldID()
            core.flushLocatorFingerprints()
        }

        // run2: id が `new_id` へドリフト。指紋で直る
        var events: [ScenarioEvent] = []
        let core = makeCore(id: "new_id", fingerprints: fingerprints, emit: { events.append($0) })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        runTapOnOldID()

        // ① 提案イベントが出ていること(旧セレクタ付き)
        let suggestion = try XCTUnwrap(events.first { $0.kind == "fixSuggestion" },
                                       "自己修復したのに提案イベントが出ていない")
        XCTAssertEqual(suggestion.oldSelector, "#old_id")
        XCTAssertEqual(suggestion.newSelector, "#new_id")

        // ② シナリオは**通っている**。そのうえで記録に残ること
        var builder = ScenarioRecordBuilder(scenarioID: "Heal.S0010", platform: "ios",
                                            title: nil, worker: nil)
        for event in events { builder.consume(event) }
        let record = builder.build(passed: true, timedOut: false, startedAt: Date(),
                                   durationMs: 1, packageRoot: nil)
        XCTAssertTrue(record.passed)
        XCTAssertEqual(record.fixSuggestions?.first?.oldSelector, "#old_id",
                       "通った run で提案が捨てられている = ヒール依存を後から数えられない")
    }
}
