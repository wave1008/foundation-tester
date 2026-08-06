import XCTest

@testable import FTDSL
import FTCore

/// 自己修復で**通った**とき、その提案が run 記録まで残ること。
/// ここが切れると「緑だがセレクタは壊れている」を後から数えられない
/// (RunResultsQuery の healReliance / RunRecord.build の doc 参照)。
/// デバイスを使わずに、DSL → ScenarioEvent → ScenarioRecordBuilder の全段を通す。
final class HealSuggestionRecordingTests: XCTestCase {

    /// `#new_id` だけが在る画面(シナリオは `#old_id` を指しているので素では解決できない)
    private final class RenamedScreenDriver: AppDriver {
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
                elements: [ElementInfo(ref: 1, type: "button", identifier: "new_id", label: "OK",
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

    /// 改名先を必ず提案する delegate(FM の代わり)
    private final class RenamingHealer: ReplayDelegate {
        func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealProposal? {
            snapshot.elements.first.map {
                HealProposal(element: $0, confidence: "high", rationale: "id renamed")
            }
        }
        func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? { nil }
        func triage(goal: String?, stepDescription: String, failureReason: String,
                    snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? { nil }
    }

    func testHealSuggestionSurvivesIntoThePassingRunRecord() throws {
        var events: [ScenarioEvent] = []
        let core = FTDriveCore(
            driver: RenamedScreenDriver(), platform: "ios", app: "com.example.app",
            scenarioID: "Heal.S0010", scenarioTitle: "t",
            delegate: RenamingHealer(), healingEnabled: true,
            falsePositiveCheckEnabled: false, dryRun: false,
            healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ft-heal-record-test-\(UUID().uuidString).json"),
            emit: { events.append($0) })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { tap("#old_id") } } }

        // ① 提案イベントが出ていること(旧セレクタ付き)
        let suggestion = try XCTUnwrap(events.first { $0.kind == "fixSuggestion" },
                                       "自己修復したのに提案イベントが出ていない")
        XCTAssertEqual(suggestion.oldSelector, "#old_id")

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
